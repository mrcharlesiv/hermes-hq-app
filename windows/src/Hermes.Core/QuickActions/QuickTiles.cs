using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Kanban;

namespace Hermes.Core.QuickActions;

// [quick-actions] The Favorites page (was Quick Actions; docs/spec/3x-morepages.md §25, docs/spec/3x-intents.md
// DECISION I22): a port of the pure parts of HermesKit/Intents/QuickTiles.swift and FavoritePages.swift — all 28 tile
// kinds (actions, 10 native live cards, Dashboard tiles, deeper shortcuts, routines, sections), 7 tile sizes,
// multi-page spaces (`FavoritePage`), 4 starter presets (`FavoritePreset`), storage (`hqn.quickActions`, versioned),
// edits, starter set, unedited-starter detection, pin dedup helpers, and subtitles.

/// What a tile does or shows. Stored by its raw value (`QuickTileKinds.Raw`); a kind this build doesn't know is kept
/// and drawn switched off.
public enum QuickTileKind
{
    // Original 9 kinds (names and raw values preserved for stored lists, shortcuts, and tests)
    NewChat,
    Memo,
    Talk,
    Send,
    OpenChat,
    AddTask,
    RunJob,
    Page,
    Search,

    /// [favorites-live-tiles] A Dashboard tile itself, drawn as the Dashboard draws it.
    DashboardTile,

    // 10 native live cards
    Tasks,
    Goal,
    NeedsYou,
    BotCard,
    GroupChat,
    ChatSession,
    JobCard,
    Kanban,
    GatewayStatus,
    Usage,

    // Deeper destinations, smart actions, routines & organization
    Prompt,
    SlashCommand,
    QuickAsk,
    DashboardPage,
    FilesFolder,
    Link,
    Routine,
    Section,
}

/// The tile colours (`accent` is the theme's tint).
public enum QuickTileColor { Accent, Red, Orange, Yellow, Green, Teal, Indigo, Pink, Gray }

/// Grid footprint of a tile (`QuickTileSize` in `QuickTiles.swift`). `null` on `QuickTile.Size` resolves from `Wide`
/// (`false` → `Small`, `true` → `Wide`).
public enum QuickTileSize
{
    Mini,
    Small,
    Wide,
    TallCard,
    Large,
    Banner,
    ExtraLarge,
}

public static class QuickTileKinds
{
    public static string Raw(this QuickTileKind kind) => kind switch
    {
        QuickTileKind.NewChat => "new-chat",
        QuickTileKind.Memo => "memo",
        QuickTileKind.Talk => "talk",
        QuickTileKind.Send => "send",
        QuickTileKind.OpenChat => "open-chat",
        QuickTileKind.AddTask => "add-task",
        QuickTileKind.RunJob => "run-job",
        QuickTileKind.Page => "page",
        QuickTileKind.Search => "search",
        QuickTileKind.DashboardTile => "dashboard-tile",
        QuickTileKind.Tasks => "tasks",
        QuickTileKind.Goal => "goal",
        QuickTileKind.NeedsYou => "needs-you",
        QuickTileKind.BotCard => "bot-card",
        QuickTileKind.GroupChat => "group-chat",
        QuickTileKind.ChatSession => "chat-session",
        QuickTileKind.JobCard => "job-card",
        QuickTileKind.Kanban => "kanban",
        QuickTileKind.GatewayStatus => "gateway-status",
        QuickTileKind.Usage => "usage",
        QuickTileKind.Prompt => "prompt",
        QuickTileKind.SlashCommand => "slash-command",
        QuickTileKind.QuickAsk => "quick-ask",
        QuickTileKind.DashboardPage => "dashboard-page",
        QuickTileKind.FilesFolder => "files-folder",
        QuickTileKind.Link => "link",
        QuickTileKind.Routine => "routine",
        QuickTileKind.Section => "section",
        _ => "search",
    };

    /// The kind for a stored raw value; null for one this build doesn't know.
    public static QuickTileKind? Parse(string? raw) =>
        raw == null ? null : Enum.GetValues<QuickTileKind>().Cast<QuickTileKind?>().FirstOrDefault(k => k!.Value.Raw() == raw);

    /// Done in the background: the page stays open and says what happened.
    public static bool StaysOnPage(this QuickTileKind kind) => kind is QuickTileKind.RunJob or QuickTileKind.Section;

    public static bool NeedsBot(this QuickTileKind kind) => kind is
        QuickTileKind.NewChat or QuickTileKind.Memo or QuickTileKind.Talk or QuickTileKind.Send or QuickTileKind.OpenChat
        or QuickTileKind.BotCard or QuickTileKind.Prompt or QuickTileKind.SlashCommand or QuickTileKind.QuickAsk;

    /// [favorites-live-tiles] A picture, not an icon and words: Set Up has no icon grid, colour or Height, and it is never Short.
    public static bool IsPicture(this QuickTileKind kind) => kind == QuickTileKind.DashboardTile;

    /// Native live card rendered by `FavoriteLiveCards` (not a static icon square).
    public static bool IsLiveCard(this QuickTileKind kind) => kind is
        QuickTileKind.Tasks or QuickTileKind.Goal or QuickTileKind.NeedsYou or QuickTileKind.BotCard
        or QuickTileKind.GroupChat or QuickTileKind.ChatSession or QuickTileKind.JobCard or QuickTileKind.Kanban
        or QuickTileKind.GatewayStatus or QuickTileKind.Usage;

    /// Any rich visual widget (Dashboard tile or native live card).
    public static bool IsWidget(this QuickTileKind kind) => kind.IsPicture() || kind.IsLiveCard();

    /// Section divider/header row.
    public static bool IsSection(this QuickTileKind kind) => kind == QuickTileKind.Section;

    /// Supports multi-row sizes (Large 2×2, Vertical 1×2, Banner, Extra Large).
    public static bool SupportsMultiRowSize(this QuickTileKind kind) => kind.IsWidget();

    /// Supports the compact 4-across Mini action strip size.
    public static bool SupportsMini(this QuickTileKind kind) => !kind.IsWidget() && !kind.IsSection();

    /// Supports one-line Short action tile height.
    public static bool SupportsShort(this QuickTileKind kind) => !kind.IsWidget() && !kind.IsSection();

    /// Supports custom icon + color pickers in Set Up.
    public static bool SupportsCustomLook(this QuickTileKind kind) => !kind.IsWidget() && !kind.IsSection();

    /// Supports toggling the bot's face avatar in place of the icon square.
    public static bool SupportsAvatarOption(this QuickTileKind kind) => kind is
        QuickTileKind.NewChat or QuickTileKind.Memo or QuickTileKind.Talk or QuickTileKind.Send or QuickTileKind.OpenChat
        or QuickTileKind.Prompt or QuickTileKind.SlashCommand or QuickTileKind.QuickAsk;

    /// The name a new tile of this kind is given (the setup form's Name starts with it).
    public static string DefaultName(this QuickTileKind kind, string? bot, string? job, string? page) => kind switch
    {
        QuickTileKind.NewChat => "New Chat",
        QuickTileKind.Memo => "Memo",
        QuickTileKind.Talk => "Talk",
        QuickTileKind.Send => "Message",
        QuickTileKind.OpenChat => string.IsNullOrEmpty(bot) ? "Open Chat" : bot,
        QuickTileKind.AddTask => "Add Task",
        QuickTileKind.RunJob => string.IsNullOrEmpty(job) ? "Run Job" : job,
        QuickTileKind.Page => string.IsNullOrEmpty(page) ? "Page" : page,
        QuickTileKind.Search => "Search Chats",
        QuickTileKind.DashboardTile => string.IsNullOrEmpty(page) ? "Tile" : page,
        QuickTileKind.Tasks => string.IsNullOrEmpty(page) ? "Today" : page,
        QuickTileKind.Goal => string.IsNullOrEmpty(page) ? "Goal" : page,
        QuickTileKind.NeedsYou => "Needs You",
        QuickTileKind.BotCard => string.IsNullOrEmpty(bot) ? "Bot" : bot,
        QuickTileKind.GroupChat => string.IsNullOrEmpty(page) ? "Group Chat" : page,
        QuickTileKind.ChatSession => string.IsNullOrEmpty(page) ? "Chat" : page,
        QuickTileKind.JobCard => string.IsNullOrEmpty(job) ? "Upcoming Jobs" : job,
        QuickTileKind.Kanban => string.IsNullOrEmpty(page) ? "Kanban" : page,
        QuickTileKind.GatewayStatus => "Gateway",
        QuickTileKind.Usage => "Usage",
        QuickTileKind.Prompt => string.IsNullOrEmpty(page) ? "Saved Prompt" : page,
        QuickTileKind.SlashCommand => string.IsNullOrEmpty(page) ? "Command" : page,
        QuickTileKind.QuickAsk => string.IsNullOrEmpty(bot) ? "Quick Ask" : $"Ask {bot}",
        QuickTileKind.DashboardPage => string.IsNullOrEmpty(page) ? "Dashboard Page" : page,
        QuickTileKind.FilesFolder => string.IsNullOrEmpty(page) ? "Folder" : page,
        QuickTileKind.Link => string.IsNullOrEmpty(page) ? "Web Link" : page,
        QuickTileKind.Routine => "Routine",
        QuickTileKind.Section => "Section",
        _ => "Search Chats",
    };

    /// The icon (the Mac's SF Symbol name, as stored) and colour a new tile of this kind starts with.
    public static (string Symbol, QuickTileColor Color) DefaultLook(this QuickTileKind kind) => kind switch
    {
        QuickTileKind.NewChat => ("square.and.pencil", QuickTileColor.Accent),
        QuickTileKind.Memo => ("mic.fill", QuickTileColor.Red),
        QuickTileKind.Talk => ("waveform", QuickTileColor.Green),
        QuickTileKind.Send => ("paperplane.fill", QuickTileColor.Indigo),
        QuickTileKind.OpenChat => ("bubble.left.fill", QuickTileColor.Green),
        QuickTileKind.AddTask => ("checklist", QuickTileColor.Teal),
        QuickTileKind.RunJob => ("bolt.fill", QuickTileColor.Orange),
        QuickTileKind.Page => ("square.grid.2x2.fill", QuickTileColor.Gray),
        QuickTileKind.Search => ("magnifyingglass", QuickTileColor.Gray),
        QuickTileKind.DashboardTile => ("chart.xyaxis.line", QuickTileColor.Accent),
        QuickTileKind.Tasks => ("checklist", QuickTileColor.Orange),
        QuickTileKind.Goal => ("target", QuickTileColor.Green),
        QuickTileKind.NeedsYou => ("bell.badge.fill", QuickTileColor.Orange),
        QuickTileKind.BotCard => ("person.crop.circle.fill", QuickTileColor.Accent),
        QuickTileKind.GroupChat => ("person.2.fill", QuickTileColor.Teal),
        QuickTileKind.ChatSession => ("bubble.left.and.bubble.right.fill", QuickTileColor.Indigo),
        QuickTileKind.JobCard => ("calendar.badge.clock", QuickTileColor.Orange),
        QuickTileKind.Kanban => ("rectangle.split.3x1.fill", QuickTileColor.Yellow),
        QuickTileKind.GatewayStatus => ("gauge.with.dots.needle.67percent", QuickTileColor.Gray),
        QuickTileKind.Usage => ("chart.bar.fill", QuickTileColor.Accent),
        QuickTileKind.Prompt => ("text.quote", QuickTileColor.Indigo),
        QuickTileKind.SlashCommand => ("command", QuickTileColor.Pink),
        QuickTileKind.QuickAsk => ("sparkles", QuickTileColor.Accent),
        QuickTileKind.DashboardPage => ("rectangle.3.group.fill", QuickTileColor.Orange),
        QuickTileKind.FilesFolder => ("folder.fill", QuickTileColor.Accent),
        QuickTileKind.Link => ("globe", QuickTileColor.Teal),
        QuickTileKind.Routine => ("wand.and.stars", QuickTileColor.Pink),
        QuickTileKind.Section => ("line.3.horizontal", QuickTileColor.Gray),
        _ => ("magnifyingglass", QuickTileColor.Gray),
    };

    public static string Raw(this QuickTileColor color) => color.ToString().ToLowerInvariant();

    public static QuickTileColor? ParseColor(string? raw) =>
        raw == null ? null : Enum.GetValues<QuickTileColor>().Cast<QuickTileColor?>().FirstOrDefault(c => c!.Value.Raw() == raw);
}

public static class QuickTileSizes
{
    public static readonly QuickTileSize[] All =
    [
        QuickTileSize.Mini, QuickTileSize.Small, QuickTileSize.Wide, QuickTileSize.TallCard,
        QuickTileSize.Large, QuickTileSize.Banner, QuickTileSize.ExtraLarge,
    ];

    public static string Raw(this QuickTileSize size) => size switch
    {
        QuickTileSize.Mini => "mini",
        QuickTileSize.Small => "small",
        QuickTileSize.Wide => "wide",
        QuickTileSize.TallCard => "tall-card",
        QuickTileSize.Large => "large",
        QuickTileSize.Banner => "banner",
        QuickTileSize.ExtraLarge => "extra-large",
        _ => "small",
    };

    public static QuickTileSize? Parse(string? raw) => raw switch
    {
        "mini" => QuickTileSize.Mini,
        "small" => QuickTileSize.Small,
        "wide" => QuickTileSize.Wide,
        "tall-card" => QuickTileSize.TallCard,
        "large" => QuickTileSize.Large,
        "banner" => QuickTileSize.Banner,
        "extra-large" => QuickTileSize.ExtraLarge,
        _ => null,
    };

    /// Human title for menus and pickers (avoids "Tall" for widgets so Q16's "no Tall/Short for pictures" stays distinct).
    public static string Title(this QuickTileSize size) => size switch
    {
        QuickTileSize.Mini => "Mini",
        QuickTileSize.Small => "Small",
        QuickTileSize.Wide => "Wide",
        QuickTileSize.TallCard => "Vertical",
        QuickTileSize.Large => "Large",
        QuickTileSize.Banner => "Banner",
        QuickTileSize.ExtraLarge => "Extra Large",
        _ => "Small",
    };

    public static string Symbol(this QuickTileSize size) => size switch
    {
        QuickTileSize.Mini => "square.grid.2x2",
        QuickTileSize.Small => "square",
        QuickTileSize.Wide => "rectangle",
        QuickTileSize.TallCard => "rectangle.portrait",
        QuickTileSize.Large => "square.grid.2x2.fill",
        QuickTileSize.Banner => "rectangle.split.1x2",
        QuickTileSize.ExtraLarge => "rectangle.inset.filled",
        _ => "square",
    };

    public static bool IsWideSpan(this QuickTileSize size) =>
        size is QuickTileSize.Wide or QuickTileSize.Large or QuickTileSize.Banner or QuickTileSize.ExtraLarge;

    public static int RowSpan(this QuickTileSize size) =>
        size is QuickTileSize.TallCard or QuickTileSize.Large or QuickTileSize.ExtraLarge ? 2 : 1;

    public static int ColSpan(this QuickTileSize size, int columns) => size switch
    {
        QuickTileSize.Mini or QuickTileSize.Small or QuickTileSize.TallCard => 1,
        QuickTileSize.Wide or QuickTileSize.Large => Math.Min(2, Math.Max(1, columns)),
        QuickTileSize.Banner or QuickTileSize.ExtraLarge => Math.Max(1, columns),
        _ => 1,
    };

    /// Sizes offered in Set Up / menus for a tile kind (on `wideScreen` >= 3 columns, Banner & Extra Large also appear).
    public static IReadOnlyList<QuickTileSize> Choices(QuickTileKind kind, bool wideScreen = false)
    {
        if (kind.IsSection()) return [QuickTileSize.Banner];
        if (kind.IsWidget())
        {
            return wideScreen
                ? [QuickTileSize.Small, QuickTileSize.Wide, QuickTileSize.TallCard, QuickTileSize.Large, QuickTileSize.Banner, QuickTileSize.ExtraLarge]
                : [QuickTileSize.Small, QuickTileSize.Wide, QuickTileSize.TallCard, QuickTileSize.Large];
        }
        return wideScreen
            ? [QuickTileSize.Mini, QuickTileSize.Small, QuickTileSize.Wide, QuickTileSize.Banner]
            : [QuickTileSize.Mini, QuickTileSize.Small, QuickTileSize.Wide];
    }

    public static IReadOnlyList<QuickTileSize> Choices(QuickTileKind? kind, bool wideScreen = false) =>
        kind is { } k ? Choices(k, wideScreen) : [QuickTileSize.Small, QuickTileSize.Wide];
}

/// Step kinds inside a `Routine` multi-action tile (`QuickRoutineStep.StepKind`).
public enum QuickRoutineStepKind { RunJob, Send, SlashCommand, OpenPage, OpenChat, OpenTile }

public static class QuickRoutineStepKinds
{
    public static readonly QuickRoutineStepKind[] All =
    [
        QuickRoutineStepKind.RunJob, QuickRoutineStepKind.Send, QuickRoutineStepKind.SlashCommand,
        QuickRoutineStepKind.OpenPage, QuickRoutineStepKind.OpenChat, QuickRoutineStepKind.OpenTile,
    ];

    public static string Raw(this QuickRoutineStepKind kind) => kind switch
    {
        QuickRoutineStepKind.RunJob => "run-job",
        QuickRoutineStepKind.Send => "send",
        QuickRoutineStepKind.SlashCommand => "slash-command",
        QuickRoutineStepKind.OpenPage => "open-page",
        QuickRoutineStepKind.OpenChat => "open-chat",
        QuickRoutineStepKind.OpenTile => "open-tile",
        _ => "run-job",
    };

    public static QuickRoutineStepKind? Parse(string? raw) => raw switch
    {
        "run-job" => QuickRoutineStepKind.RunJob,
        "send" => QuickRoutineStepKind.Send,
        "slash-command" => QuickRoutineStepKind.SlashCommand,
        "open-page" => QuickRoutineStepKind.OpenPage,
        "open-chat" => QuickRoutineStepKind.OpenChat,
        "open-tile" => QuickRoutineStepKind.OpenTile,
        _ => null,
    };

    public static string Title(this QuickRoutineStepKind kind) => kind switch
    {
        QuickRoutineStepKind.RunJob => "Run Job",
        QuickRoutineStepKind.Send => "Send Message",
        QuickRoutineStepKind.SlashCommand => "Run Command",
        QuickRoutineStepKind.OpenPage => "Open Page",
        QuickRoutineStepKind.OpenChat => "Open Bot Chat",
        QuickRoutineStepKind.OpenTile => "Open Dashboard Tile",
        _ => "Step",
    };

    public static string Symbol(this QuickRoutineStepKind kind) => kind switch
    {
        QuickRoutineStepKind.RunJob => "bolt.fill",
        QuickRoutineStepKind.Send => "paperplane.fill",
        QuickRoutineStepKind.SlashCommand => "command",
        QuickRoutineStepKind.OpenPage => "square.grid.2x2.fill",
        QuickRoutineStepKind.OpenChat => "bubble.left.fill",
        QuickRoutineStepKind.OpenTile => "chart.xyaxis.line",
        _ => "bolt.fill",
    };

    public static bool IsBackground(this QuickRoutineStepKind kind) =>
        kind is QuickRoutineStepKind.RunJob or QuickRoutineStepKind.Send;
}

/// One step inside a `.routine` multi-action tile (`QuickRoutineStep` in `QuickTiles.swift`).
public sealed record QuickRoutineStep
{
    public required string Id { get; init; }
    public required string Kind { get; init; }
    public string? Bot { get; init; }
    public string? BotName { get; init; }
    public string? Message { get; init; }
    public string? Command { get; init; }
    public string? Job { get; init; }
    public string? JobName { get; init; }
    public string? Page { get; init; }
    public string? PageName { get; init; }
    public string? Pin { get; init; }
    public string? PinName { get; init; }

    public QuickRoutineStepKind? KnownKind => QuickRoutineStepKinds.Parse(Kind);

    public static QuickRoutineStep Create(
        QuickRoutineStepKind kind,
        string? id = null,
        string? bot = null,
        string? botName = null,
        string? message = null,
        string? command = null,
        string? job = null,
        string? jobName = null,
        string? page = null,
        string? pageName = null,
        string? pin = null,
        string? pinName = null) => new()
    {
        Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant(),
        Kind = kind.Raw(),
        Bot = bot,
        BotName = botName,
        Message = message,
        Command = command,
        Job = job,
        JobName = jobName,
        Page = page,
        PageName = pageName,
        Pin = pin,
        PinName = pinName,
    };

    public string Summary => KnownKind switch
    {
        QuickRoutineStepKind.RunJob => $"Run {JobName ?? Job ?? "job"}",
        QuickRoutineStepKind.Send => SendSummary(),
        QuickRoutineStepKind.SlashCommand => $"{Command ?? "/command"} to {BotName ?? Bot ?? "bot"}",
        QuickRoutineStepKind.OpenPage => $"Open {PageName ?? Page ?? "page"}",
        QuickRoutineStepKind.OpenChat => $"Open {BotName ?? Bot ?? "chat"}",
        QuickRoutineStepKind.OpenTile => $"Open {PinName ?? "tile"}",
        _ => "Unknown step",
    };

    private string SendSummary()
    {
        var who = BotName ?? Bot ?? "bot";
        var words = (Message ?? "").Trim();
        if (words.Length == 0) return $"Send to {who}";
        var snippet = words.Length > 24 ? words[..24] : words;
        return $"Send “{snippet}” to {who}";
    }

    public bool Equals(QuickRoutineStep? other)
    {
        if (ReferenceEquals(this, other)) return true;
        static bool Same(string? a, string? b) => QuickTileJson.Text.Equals(a, b);
        return other != null && Same(Id, other.Id) && Same(Kind, other.Kind) &&
            Same(Bot, other.Bot) && Same(BotName, other.BotName) && Same(Message, other.Message) &&
            Same(Command, other.Command) && Same(Job, other.Job) && Same(JobName, other.JobName) &&
            Same(Page, other.Page) && Same(PageName, other.PageName) && Same(Pin, other.Pin) && Same(PinName, other.PinName);
    }

    public override int GetHashCode() => QuickTileJson.Text.GetHashCode(Id);

    internal static QuickRoutineStep? Read(JsonElement el)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        var fields = QuickTileJson.Fields(el);
        var ok = true;
        string? Opt(string key)
        {
            if (!fields.TryGetValue(key, out var v) || v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind == JsonValueKind.String) return v.GetString();
            ok = false;
            return null;
        }
        var id = Opt("id");
        var kind = Opt("kind");
        if (!ok || id == null || kind == null) return null;
        var step = new QuickRoutineStep
        {
            Id = id,
            Kind = kind,
            Bot = Opt("bot"),
            BotName = Opt("botName"),
            Message = Opt("message"),
            Command = Opt("command"),
            Job = Opt("job"),
            JobName = Opt("jobName"),
            Page = Opt("page"),
            PageName = Opt("pageName"),
            Pin = Opt("pin"),
            PinName = Opt("pinName"),
        };
        return ok ? step : null;
    }

    internal JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["kind"] = Kind };
        void Put(string key, string? value) { if (value != null) o[key] = value; }
        Put("bot", Bot);
        Put("botName", BotName);
        Put("message", Message);
        Put("command", Command);
        Put("job", Job);
        Put("jobName", JobName);
        Put("page", Page);
        Put("pageName", PageName);
        Put("pin", Pin);
        Put("pinName", PinName);
        return o;
    }
}

/// One Favorites page / space (like `DashboardPage` on Tiles). `main` ("Home") is always present and first.
public sealed record FavoritePage(string Id, string Name, string? Symbol = null)
{
    public const string MainId = "main";
    public static readonly FavoritePage Main = new(MainId, "Home");

    public static readonly (string Symbol, string Label)[] SymbolChoices =
    [
        ("star.fill", "Favorites"),
        ("house.fill", "Home"),
        ("briefcase.fill", "Work"),
        ("sun.max.fill", "Daily"),
        ("bolt.fill", "Ops"),
        ("chart.bar.fill", "Metrics"),
        ("bubble.left.and.bubble.right.fill", "Chats"),
        ("checklist", "Tasks"),
        ("chevron.left.forwardslash.chevron.right", "Code"),
        ("heart.fill", "Personal"),
        ("sparkles", "AI"),
        ("globe", "Web"),
    ];

    public bool Equals(FavoritePage? other)
    {
        if (ReferenceEquals(this, other)) return true;
        static bool Same(string? a, string? b) => QuickTileJson.Text.Equals(a, b);
        return other != null && Same(Id, other.Id) && Same(Name, other.Name) && Same(Symbol, other.Symbol);
    }

    public override int GetHashCode() => QuickTileJson.Text.GetHashCode(Id);

    internal static FavoritePage? Read(JsonElement el)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        var fields = QuickTileJson.Fields(el);
        var ok = true;
        string? Opt(string key)
        {
            if (!fields.TryGetValue(key, out var v) || v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind == JsonValueKind.String) return v.GetString();
            ok = false;
            return null;
        }
        var id = Opt("id");
        var name = Opt("name");
        var symbol = Opt("symbol");
        if (!ok || id == null || name == null) return null;
        return new FavoritePage(id, name, string.IsNullOrEmpty(symbol) ? null : symbol);
    }

    internal static FavoritePage? FromJson(JsonNode? node)
    {
        if (node is not JsonObject o) return null;
        var id = o.Str("id");
        var name = o.Str("name");
        if (string.IsNullOrEmpty(id) || name == null) return null;
        var sym = o.Str("symbol");
        return new FavoritePage(id, name, string.IsNullOrEmpty(sym) ? null : sym);
    }

    internal JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["name"] = Name };
        if (!string.IsNullOrEmpty(Symbol)) o["symbol"] = Symbol;
        return o;
    }
}

/// One tile (`QuickTile` in `QuickTiles.swift`). Fields a kind doesn't use stay null.
public sealed record QuickTile
{
    public required string Id { get; init; }
    /// `QuickTileKind`'s raw value, kept as written: a newer build's kind survives this build's edits.
    public required string Kind { get; init; }
    public string Name { get; init; } = "";
    public string Symbol { get; init; } = "square.grid.2x2.fill";
    /// `QuickTileColor`'s raw value.
    public string Color { get; init; } = "gray";
    public bool Wide { get; init; }
    /// A Short tile is one line high: its icon beside the name and subtitle (3x-morepages Q13).
    public bool Short { get; init; }
    /// Extended footprint (`Mini`, `TallCard`, `Large`, `Banner`, `ExtraLarge`). Null falls back to `Wide`.
    public QuickTileSize? Size { get; init; }
    /// Which `FavoritePage` this tile belongs to (null = `FavoritePage.MainId`).
    public string? PageId { get; init; }
    /// Optional gateway account id scope (null = shown on all gateways).
    public string? GatewayId { get; init; }

    /// The bot's profile, and its name when the tile was set up (said when the bot isn't on this gateway).
    public string? Bot { get; init; }
    public string? BotName { get; init; }
    /// New Chat's project: its key (folder) and name.
    public string? Project { get; init; }
    public string? ProjectName { get; init; }
    /// New Chat's first message, Send a Message's words, or Saved Prompt body.
    public string? Message { get; init; }
    /// New Chat: send the first message (on) or leave it in the box. Send / Prompt / Quick Ask: open the chat (on) or background (off).
    public bool? Flag { get; init; }
    /// Run Job / Job Card: job key (`<owner>|<id>`) and its name. Null on `JobCard` = Upcoming Jobs overview.
    public string? Job { get; init; }
    public string? JobName { get; init; }
    /// A page's More row id, and its title.
    public string? Page { get; init; }
    public string? PageName { get; init; }
    /// [favorites-live-tiles] A Dashboard tile's pin (`TilePin.Id`), and its name when added.
    public string? Pin { get; init; }
    public string? PinName { get; init; }

    // Rich card & deep-target fields (omitted from JSON when null)
    /// `Tasks` view key ("today", "upcoming", "inbox", "bots", "list:<id>") and saved display name.
    public string? TaskView { get; init; }
    public string? TaskViewName { get; init; }
    /// `Goal` id and saved name.
    public string? GoalId { get; init; }
    public string? GoalName { get; init; }
    /// `GroupChat` room key and saved name.
    public string? RoomKey { get; init; }
    public string? RoomName { get; init; }
    /// `ChatSession` stored session key/id and saved title.
    public string? SessionId { get; init; }
    public string? SessionTitle { get; init; }
    /// `Kanban` board slug, board name, and optional column status filter.
    public string? BoardSlug { get; init; }
    public string? BoardName { get; init; }
    public string? ColumnStatus { get; init; }
    /// `Prompt` linked `SavedPrompt.Id` string (Message holds fallback copy if edited/deleted).
    public string? PromptId { get; init; }
    /// `SlashCommand` command string (e.g. "/usage").
    public string? Command { get; init; }
    /// `Link` external URL string.
    public string? Url { get; init; }
    /// `FilesFolder` folder path and display name.
    public string? FolderPath { get; init; }
    public string? FolderName { get; init; }
    /// `DashboardPage` page id and name.
    public string? DashboardPageId { get; init; }
    public string? DashboardPageName { get; init; }
    /// `Usage` lookback days (7, 30, 90).
    public int? Days { get; init; }
    /// `Routine` ordered steps.
    public IReadOnlyList<QuickRoutineStep>? Steps { get; init; }
    /// `Section` collapsed state (omitted when false/null).
    public bool? Collapsed { get; init; }
    /// Bot action tiles: draw the bot's face avatar instead of the icon square.
    public bool? ShowAvatar { get; init; }

    /// A stored entry this build could not read at all, as canonical JSON text: kept, written back as it was, and
    /// drawn switched off.
    public string? Unreadable { get; init; }
    // Unknown fields only. A record copy shares immutable text, never a mutable node with a parent.
    private string? ExtraJson { get; init; }

    // Swift compares the values, not their Unicode spelling. Keep that spelling for the next real edit.
    public bool Equals(QuickTile? other)
    {
        if (ReferenceEquals(this, other)) return true;
        static bool Same(string? a, string? b) => QuickTileJson.Text.Equals(a, b);
        static bool SameSteps(IReadOnlyList<QuickRoutineStep>? a, IReadOnlyList<QuickRoutineStep>? b)
        {
            var emptyA = a == null || a.Count == 0;
            var emptyB = b == null || b.Count == 0;
            if (emptyA && emptyB) return true;
            if (emptyA || emptyB) return false;
            return a!.SequenceEqual(b!);
        }
        return other != null && Wide == other.Wide && Short == other.Short && Size == other.Size &&
            Flag == other.Flag && Days == other.Days && Collapsed == other.Collapsed && ShowAvatar == other.ShowAvatar &&
            Same(Id, other.Id) && Same(Kind, other.Kind) && Same(Name, other.Name) && Same(Symbol, other.Symbol) &&
            Same(Color, other.Color) && Same(PageId, other.PageId) && Same(GatewayId, other.GatewayId) &&
            Same(Bot, other.Bot) && Same(BotName, other.BotName) &&
            Same(Project, other.Project) && Same(ProjectName, other.ProjectName) && Same(Message, other.Message) &&
            Same(Job, other.Job) && Same(JobName, other.JobName) && Same(Page, other.Page) && Same(PageName, other.PageName) &&
            Same(Pin, other.Pin) && Same(PinName, other.PinName) &&
            Same(TaskView, other.TaskView) && Same(TaskViewName, other.TaskViewName) &&
            Same(GoalId, other.GoalId) && Same(GoalName, other.GoalName) &&
            Same(RoomKey, other.RoomKey) && Same(RoomName, other.RoomName) &&
            Same(SessionId, other.SessionId) && Same(SessionTitle, other.SessionTitle) &&
            Same(BoardSlug, other.BoardSlug) && Same(BoardName, other.BoardName) && Same(ColumnStatus, other.ColumnStatus) &&
            Same(PromptId, other.PromptId) && Same(Command, other.Command) && Same(Url, other.Url) &&
            Same(FolderPath, other.FolderPath) && Same(FolderName, other.FolderName) &&
            Same(DashboardPageId, other.DashboardPageId) && Same(DashboardPageName, other.DashboardPageName) &&
            SameSteps(Steps, other.Steps) &&
            QuickTileJson.SameValue(ExtraJson, other.ExtraJson) && QuickTileJson.SameValue(Unreadable, other.Unreadable);
    }

    public override int GetHashCode() => QuickTileJson.Text.GetHashCode(Id);

    public QuickTileKind? Known => Unreadable == null ? QuickTileKinds.Parse(Kind) : null;
    public QuickTileColor Tint => QuickTileKinds.ParseColor(Color) ?? QuickTileColor.Gray;
    public string ResolvedPageId => string.IsNullOrEmpty(PageId) ? FavoritePage.MainId : PageId;

    /// Effective grid footprint, reconciling `Size`, `Wide`, and kind capabilities (`QuickTile.effectiveSize`).
    public QuickTileSize EffectiveSize
    {
        get
        {
            if (Known is { } known && known.IsSection()) return QuickTileSize.Banner;
            if (Size is { } s)
            {
                if (Known is { } k)
                {
                    if (s == QuickTileSize.Mini && !k.SupportsMini()) return QuickTileSize.Small;
                    if (!k.SupportsMultiRowSize() && s is QuickTileSize.Large or QuickTileSize.TallCard or QuickTileSize.ExtraLarge)
                        return QuickTileSize.Wide;
                }
                return s;
            }
            return Wide ? QuickTileSize.Wide : QuickTileSize.Small;
        }
    }

    /// A new tile of `kind`, with its default name and look (`QuickTile.init(id:kind:...)`). The id is a fresh UUID.
    public static QuickTile Create(QuickTileKind kind, string? id = null, string? name = null, string? symbol = null,
        QuickTileColor? color = null, bool wide = false, QuickTileSize? size = null)
    {
        var resolvedWide = size is { } s ? s.IsWideSpan() : wide;
        var resolvedSize = size is { } sz && sz is not (QuickTileSize.Small or QuickTileSize.Wide) ? sz : (QuickTileSize?)null;
        return new QuickTile
        {
            Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant(),
            Kind = kind.Raw(),
            Name = name ?? kind.DefaultName(null, null, null),
            Symbol = symbol ?? kind.DefaultLook().Symbol,
            Color = (color ?? kind.DefaultLook().Color).Raw(),
            Wide = resolvedWide,
            Size = resolvedSize,
        };
    }

    /// An entry that can't be read as a tile (`QuickTile.init(unreadable:)`).
    public static QuickTile FromUnreadable(JsonNode? raw)
    {
        var canonical = QuickTileJson.Canonical(raw);
        return new QuickTile
        {
            Id = StringOf(raw.Get("id")) ?? StableID(canonical),
            Kind = StringOf(raw.Get("kind")) ?? "unknown",
            Name = StringOf(raw.Get("name")) ?? "Unknown Action",
            Symbol = "questionmark.square.dashed",
            Color = QuickTileColor.Gray.Raw(),
            Wide = raw.Get("wide") is JsonValue w && w.GetValueKind() is JsonValueKind.True,
            Short = raw.Get("short") is JsonValue s && s.GetValueKind() is JsonValueKind.True,
            Unreadable = canonical,
        };
    }

    private static string? StringOf(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    /// The same id for the same stored bytes on every read (FNV-1a over the entry's sorted JSON), so an entry without a
    /// readable id can still be removed or moved.
    private static string StableID(string canonical)
    {
        ulong hash = 0xcbf29ce484222325;
        foreach (var b in Encoding.UTF8.GetBytes(canonical))
        {
            hash ^= b;
            hash = unchecked(hash * 0x00000100000001b3);
        }
        return "unreadable-" + hash.ToString("x");
    }

    /// Reads a stored entry as a tile, strictly as the Swift decoder does (wrong types fail); null when it can't.
    internal static QuickTile? Read(JsonElement row)
    {
        if (row.ValueKind != JsonValueKind.Object) return null;
        // Only consume keys in our own dictionary. The source row remains available for the unreadable fallback.
        var remaining = QuickTileJson.Fields(row);
        JsonElement Take(string key) => remaining.Remove(key, out var value) ? value : default;
        var ok = true;
        string? Opt(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind == JsonValueKind.String) return v.GetString();
            ok = false;
            return null;
        }
        bool? OptBool(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind is JsonValueKind.True or JsonValueKind.False) return v.GetBoolean();
            ok = false;
            return null;
        }
        int? OptInt(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)) return n;
            ok = false;
            return null;
        }
        QuickTileSize? OptSize(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind == JsonValueKind.String && QuickTileSizes.Parse(v.GetString()) is { } sz) return sz;
            ok = false;
            return null;
        }
        IReadOnlyList<QuickRoutineStep>? OptSteps(string key)
        {
            var v = Take(key);
            if (v.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
            if (v.ValueKind != JsonValueKind.Array) { ok = false; return null; }
            var list = new List<QuickRoutineStep>();
            foreach (var item in v.EnumerateArray())
            {
                if (QuickRoutineStep.Read(item) is not { } step) { ok = false; return null; }
                list.Add(step);
            }
            return list;
        }

        var id = Opt("id");
        var kind = Opt("kind");
        if (id == null || kind == null) return null;
        var tile = new QuickTile
        {
            Id = id,
            Kind = kind,
            Name = Opt("name") ?? "",
            Symbol = Opt("symbol") ?? "square.grid.2x2.fill",
            Color = Opt("color") ?? QuickTileColor.Gray.Raw(),
            Wide = OptBool("wide") ?? false,
            Short = OptBool("short") ?? false,
            Size = OptSize("size"),
            PageId = Opt("pageId"),
            GatewayId = Opt("gatewayId"),
            Bot = Opt("bot"),
            BotName = Opt("botName"),
            Project = Opt("project"),
            ProjectName = Opt("projectName"),
            Message = Opt("message"),
            Flag = OptBool("flag"),
            Job = Opt("job"),
            JobName = Opt("jobName"),
            Page = Opt("page"),
            PageName = Opt("pageName"),
            Pin = Opt("pin"),
            PinName = Opt("pinName"),
            TaskView = Opt("taskView"),
            TaskViewName = Opt("taskViewName"),
            GoalId = Opt("goalId"),
            GoalName = Opt("goalName"),
            RoomKey = Opt("roomKey"),
            RoomName = Opt("roomName"),
            SessionId = Opt("sessionId"),
            SessionTitle = Opt("sessionTitle"),
            BoardSlug = Opt("boardSlug"),
            BoardName = Opt("boardName"),
            ColumnStatus = Opt("columnStatus"),
            PromptId = Opt("promptId"),
            Command = Opt("command"),
            Url = Opt("url"),
            FolderPath = Opt("folderPath"),
            FolderName = Opt("folderName"),
            DashboardPageId = Opt("dashboardPageId"),
            DashboardPageName = Opt("dashboardPageName"),
            Days = OptInt("days"),
            Steps = OptSteps("steps"),
            Collapsed = OptBool("collapsed"),
            ShowAvatar = OptBool("showAvatar"),
        };
        if (!ok) return null;
        if (remaining.Count == 0) return tile;
        // Swift's optional JSONValue decode drops the extras as a group if one isn't representable.
        try { return tile with { ExtraJson = QuickTileJson.Canonical(QuickTileJson.Object(remaining)) }; }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return tile; }
    }

    /// Keep unreadable rows whole. On readable rows, only true size flags and non-null known optionals are written.
    internal JsonNode? ToJson()
    {
        if (Unreadable != null) return JsonNode.Parse(Unreadable, documentOptions: QuickTileJson.ReadOptions);
        var o = ExtraJson == null ? new JsonObject() : JsonNode.Parse(ExtraJson, documentOptions: QuickTileJson.ReadOptions)!.AsObject();
        o["id"] = Id;
        o["kind"] = Kind;
        o["name"] = Name;
        o["symbol"] = Symbol;
        o["color"] = Color;
        if (Wide) o["wide"] = true;
        if (Short) o["short"] = true;
        if (Size is { } sz && !(sz == QuickTileSize.Small && !Wide) && !(sz == QuickTileSize.Wide && Wide))
            o["size"] = sz.Raw();
        if (!string.IsNullOrEmpty(PageId) && PageId != FavoritePage.MainId) o["pageId"] = PageId;
        if (!string.IsNullOrEmpty(GatewayId)) o["gatewayId"] = GatewayId;
        void Put(string key, string? value) { if (value != null) o[key] = value; }
        Put("bot", Bot);
        Put("botName", BotName);
        Put("project", Project);
        Put("projectName", ProjectName);
        Put("message", Message);
        if (Flag is { } flag) o["flag"] = flag;
        Put("job", Job);
        Put("jobName", JobName);
        Put("page", Page);
        Put("pageName", PageName);
        Put("pin", Pin);
        Put("pinName", PinName);
        Put("taskView", TaskView);
        Put("taskViewName", TaskViewName);
        Put("goalId", GoalId);
        Put("goalName", GoalName);
        Put("roomKey", RoomKey);
        Put("roomName", RoomName);
        Put("sessionId", SessionId);
        Put("sessionTitle", SessionTitle);
        Put("boardSlug", BoardSlug);
        Put("boardName", BoardName);
        Put("columnStatus", ColumnStatus);
        Put("promptId", PromptId);
        Put("command", Command);
        Put("url", Url);
        Put("folderPath", FolderPath);
        Put("folderName", FolderName);
        Put("dashboardPageId", DashboardPageId);
        Put("dashboardPageName", DashboardPageName);
        if (Days is { } days) o["days"] = days;
        if (Steps is { Count: > 0 } steps)
        {
            var arr = new JsonArray();
            foreach (var s in steps) arr.Add(s.ToJson());
            o["steps"] = arr;
        }
        if (Collapsed == true) o["collapsed"] = true;
        if (ShowAvatar == true) o["showAvatar"] = true;
        return o;
    }

    /// [favorites-live-tiles] A Dashboard tile's name: its own, or the pin's name now while it was never typed over.
    public string ShownName(string? currentPinName) =>
        Known == QuickTileKind.DashboardTile && !string.IsNullOrEmpty(currentPinName) && (Name == PinName || Name.Length == 0)
            ? currentPinName
            : Name;

    /// What the tile does, in a few words under its name ("to otto", "in Site", "run job").
    public string Subtitle(string? currentBotName)
    {
        var who = currentBotName ?? BotName ?? Bot ?? "";
        return Known switch
        {
            QuickTileKind.Memo => $"to {who}",
            QuickTileKind.Talk => $"with {who}",
            QuickTileKind.NewChat => (ProjectName ?? Project) is { Length: > 0 } project ? $"in {project}" : $"with {who}",
            QuickTileKind.Send => Flag == true ? $"with {who}" : $"asks {who}",
            QuickTileKind.OpenChat => $"chat with {who}",
            QuickTileKind.AddTask => Bot == null ? "for me" : $"for {who}",
            QuickTileKind.RunJob => "run job",
            QuickTileKind.Page => "page",
            QuickTileKind.Search => "all chats",
            QuickTileKind.DashboardTile => "tile",
            QuickTileKind.Tasks => TaskViewName ?? "tasks",
            QuickTileKind.Goal => "goal",
            QuickTileKind.NeedsYou => "attention",
            QuickTileKind.BotCard => who.Length == 0 ? "bot" : who,
            QuickTileKind.GroupChat => "group chat",
            QuickTileKind.ChatSession => who.Length == 0 ? "chat" : $"with {who}",
            QuickTileKind.JobCard => string.IsNullOrEmpty(Job) ? "upcoming jobs" : "job",
            QuickTileKind.Kanban => !string.IsNullOrEmpty(ColumnStatus) ? KanbanModel.Label(ColumnStatus) : BoardName ?? "board",
            QuickTileKind.GatewayStatus => "status",
            QuickTileKind.Usage => $"{Days ?? 7} days",
            QuickTileKind.Prompt => Flag == true ? $"with {who}" : $"asks {who}",
            QuickTileKind.SlashCommand => (Command ?? "/command") is var cmd && who.Length == 0 ? cmd : $"{cmd} · {who}",
            QuickTileKind.QuickAsk => who.Length == 0 ? "quick ask" : $"ask {who}",
            QuickTileKind.DashboardPage => "dashboard",
            QuickTileKind.FilesFolder => FolderName ?? "files",
            QuickTileKind.Link => LinkHostSubtitle(Url),
            QuickTileKind.Routine => (Steps?.Count ?? 0) is var count && count == 1 ? "1 step" : $"{count} steps",
            QuickTileKind.Section => "section",
            _ => "needs a newer app",
        };
    }

    private static string LinkHostSubtitle(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "link";
        if (QuickTileRoute.NormalizedUrl(raw) is { Host.Length: > 0 } uri)
            return uri.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? uri.Host[4..] : uri.Host;
        return "link";
    }
}

/// The Favorites tiles and pages (`QuickTileList` in `QuickTiles.swift`). A value: use `Copy()` before editing a list
/// someone else holds.
public sealed class QuickTileList : IEquatable<QuickTileList>
{
    private readonly List<QuickTile> _tiles;
    private readonly List<FavoritePage> _pages;

    public QuickTileList() : this([], false, null) { }

    public QuickTileList(IEnumerable<QuickTile> tiles, bool seeded) : this(tiles, seeded, null) { }

    public QuickTileList(IEnumerable<QuickTile> tiles, bool seeded, IEnumerable<FavoritePage>? pages)
    {
        _tiles = tiles.ToList();
        Seeded = seeded;
        _pages = pages?.ToList() ?? [];
    }

    public IReadOnlyList<QuickTile> Tiles => _tiles;
    /// The starter set was offered once (or the person changed the list): never seeded again.
    public bool Seeded { get; set; }
    /// Additional pages/spaces. Empty means only the default `Home` (`main`) page exists.
    public IReadOnlyList<FavoritePage> Pages => _pages;

    /// Always starts with `main`.
    public IReadOnlyList<FavoritePage> AllPages
    {
        get
        {
            if (_pages.Count == 0) return [FavoritePage.Main];
            if (_pages[0].Id == FavoritePage.MainId) return _pages;
            var main = _pages.FirstOrDefault(p => p.Id == FavoritePage.MainId) ?? FavoritePage.Main;
            return [main, .. _pages.Where(p => p.Id != FavoritePage.MainId)];
        }
    }

    public bool HasMultiplePages => AllPages.Count > 1;

    /// [favorites-live-tiles] The pins already on the page (Add Action leaves them out).
    public IReadOnlySet<string> Pins =>
        _tiles.Where(t => t.Known == QuickTileKind.DashboardTile && !string.IsNullOrEmpty(t.Pin))
            .Select(t => t.Pin!)
            .ToHashSet(StringComparer.Ordinal);

    public QuickTileList Copy() => new(_tiles, Seeded, _pages);

    /// Tiles belonging to `pageId` (default: `main`).
    public List<QuickTile> TilesOn(string pageId = FavoritePage.MainId)
    {
        var target = string.IsNullOrEmpty(pageId) ? FavoritePage.MainId : pageId;
        return _tiles.Where(t => t.ResolvedPageId == target).ToList();
    }

    /// Tiles shown on `pageId`, hiding items inside collapsed sections unless `includeCollapsed` is true.
    public List<QuickTile> VisibleTiles(string pageId = FavoritePage.MainId, bool includeCollapsed = false)
    {
        var onPage = TilesOn(pageId);
        if (includeCollapsed) return onPage;
        var output = new List<QuickTile>(onPage.Count);
        var hiding = false;
        foreach (var tile in onPage)
        {
            if (tile.Known == QuickTileKind.Section)
            {
                hiding = tile.Collapsed == true;
                output.Add(tile);
            }
            else if (!hiding)
            {
                output.Add(tile);
            }
        }
        return output;
    }

    /// How many tiles sit under `sectionId` before the next section header on `pageId`.
    public int SectionItemCount(string sectionId, string pageId = FavoritePage.MainId)
    {
        var onPage = TilesOn(pageId);
        var start = onPage.FindIndex(t => t.Id == sectionId);
        if (start < 0) return 0;
        var count = 0;
        for (var i = start + 1; i < onPage.Count; i++)
        {
            if (onPage[i].Known == QuickTileKind.Section) break;
            count++;
        }
        return count;
    }

    public void Add(QuickTile tile) => _tiles.Add(tile);

    public void Replace(QuickTile tile)
    {
        var index = _tiles.FindIndex(t => t.Id == tile.Id);
        if (index >= 0) _tiles[index] = tile; else _tiles.Add(tile);
    }

    public void Remove(string id) => _tiles.RemoveAll(t => t.Id == id);

    public void RemoveOnPage(string pageId)
    {
        var target = string.IsNullOrEmpty(pageId) ? FavoritePage.MainId : pageId;
        _tiles.RemoveAll(t => t.ResolvedPageId == target);
    }

    public QuickTile? Duplicate(string id)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index < 0) return null;
        var src = _tiles[index];
        var copy = src with
        {
            Id = Guid.NewGuid().ToString().ToUpperInvariant(),
            Name = string.IsNullOrEmpty(src.Name) ? "Copy" : $"{src.Name} Copy",
        };
        _tiles.Insert(index + 1, copy);
        return copy;
    }

    public void SetWide(string id, bool wide)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index < 0) return;
        _tiles[index] = _tiles[index] with { Wide = wide, Size = null };
    }

    /// A Dashboard tile or live card is never Short: it stays as it is.
    public void SetShort(string id, bool isShort)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index < 0) return;
        if (_tiles[index].Known is { } kind && !kind.SupportsShort()) return;
        var next = _tiles[index] with { Short = isShort };
        if (isShort && next.Size == QuickTileSize.Mini) next = next with { Size = null };
        _tiles[index] = next;
    }

    /// Sets any size from the full `QuickTileSize` vocabulary, keeping `Wide` and `Short` consistent.
    public void SetSize(string id, QuickTileSize next)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index < 0) return;
        var kind = _tiles[index].Known;
        if (kind is { } k && k.IsSection()) return;
        if (next == QuickTileSize.Mini && kind is { } km && !km.SupportsMini()) return;
        if (next is QuickTileSize.Large or QuickTileSize.TallCard or QuickTileSize.ExtraLarge && kind is { } kw && !kw.SupportsMultiRowSize())
            return;
        var clearShort = next == QuickTileSize.Mini || next.RowSpan() > 1 || (kind is { } ks && !ks.SupportsShort());
        _tiles[index] = _tiles[index] with
        {
            Wide = next.IsWideSpan(),
            Size = next is QuickTileSize.Small or QuickTileSize.Wide ? null : next,
            Short = clearShort ? false : _tiles[index].Short,
        };
    }

    public void ToggleSection(string id)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index < 0 || _tiles[index].Known != QuickTileKind.Section) return;
        var next = !(_tiles[index].Collapsed ?? false);
        _tiles[index] = _tiles[index] with { Collapsed = next ? true : null };
    }

    public void MoveTile(string id, string toPageId)
    {
        var index = _tiles.FindIndex(t => t.Id == id);
        if (index < 0) return;
        _tiles[index] = _tiles[index] with
        {
            PageId = string.IsNullOrEmpty(toPageId) || toPageId == FavoritePage.MainId ? null : toPageId,
        };
    }

    // ------------------------------------------------------------------ pages management

    public FavoritePage AddPage(string name, string? symbol = null)
    {
        EnsureMainPage();
        var cleaned = name.Trim();
        var page = new FavoritePage(
            Guid.NewGuid().ToString().ToUpperInvariant(),
            cleaned.Length == 0 ? $"Page {_pages.Count}" : cleaned,
            string.IsNullOrWhiteSpace(symbol) ? null : symbol.Trim());
        _pages.Add(page);
        return page;
    }

    public void RenamePage(string id, string name)
    {
        var cleaned = name.Trim();
        if (cleaned.Length == 0) return;
        EnsureMainPage();
        var index = _pages.FindIndex(p => p.Id == id);
        if (index >= 0) _pages[index] = _pages[index] with { Name = cleaned };
    }

    public void SetPageSymbol(string id, string? symbol)
    {
        EnsureMainPage();
        var index = _pages.FindIndex(p => p.Id == id);
        if (index >= 0) _pages[index] = _pages[index] with { Symbol = string.IsNullOrWhiteSpace(symbol) ? null : symbol.Trim() };
    }

    public void ReorderPage(string sourceId, string targetId)
    {
        if (sourceId == FavoritePage.MainId || targetId == FavoritePage.MainId || sourceId == targetId) return;
        EnsureMainPage();
        var from = _pages.FindIndex(p => p.Id == sourceId);
        var to = _pages.FindIndex(p => p.Id == targetId);
        if (from < 1 || to < 1) return;
        var moving = _pages[from];
        _pages.RemoveAt(from);
        _pages.Insert(Math.Clamp(to, 1, _pages.Count), moving);
    }

    public bool MovePage(string id, int delta)
    {
        if (id == FavoritePage.MainId || delta == 0) return false;
        EnsureMainPage();
        var from = _pages.FindIndex(p => p.Id == id);
        var to = from + delta;
        if (from < 1 || to < 1 || to >= _pages.Count) return false;
        (_pages[from], _pages[to]) = (_pages[to], _pages[from]);
        return true;
    }

    /// Removes a custom page; tiles on it move back to `main` (unless `deleteTiles` is true).
    public void DeletePage(string id, bool deleteTiles = false)
    {
        if (id == FavoritePage.MainId) return;
        _pages.RemoveAll(p => p.Id == id);
        if (deleteTiles)
        {
            _tiles.RemoveAll(t => t.ResolvedPageId == id);
        }
        else
        {
            for (var i = 0; i < _tiles.Count; i++)
                if (_tiles[i].ResolvedPageId == id) _tiles[i] = _tiles[i] with { PageId = null };
        }
        if (_pages.Count <= 1 && _pages.FirstOrDefault() == FavoritePage.Main) _pages.Clear();
    }

    public void SetPages(IEnumerable<FavoritePage> pages)
    {
        _pages.Clear();
        _pages.AddRange(pages);
    }

    private void EnsureMainPage()
    {
        if (_pages.Count == 0) _pages.Add(FavoritePage.Main);
        else if (_pages.All(p => p.Id != FavoritePage.MainId)) _pages.Insert(0, FavoritePage.Main);
    }

    // ------------------------------------------------------------------ ordering

    /// Moves the tile to `index` (clamped).
    public void Move(string id, int index)
    {
        var from = _tiles.FindIndex(t => t.Id == id);
        if (from < 0) return;
        var tile = _tiles[from];
        _tiles.RemoveAt(from);
        _tiles.Insert(Math.Max(0, Math.Min(index, _tiles.Count)), tile);
    }

    /// One step earlier (-1) or later (+1); false at an end.
    public bool Step(string id, int delta)
    {
        var from = _tiles.FindIndex(t => t.Id == id);
        var to = from + delta;
        if (from < 0 || to < 0 || to >= _tiles.Count) return false;
        (_tiles[from], _tiles[to]) = (_tiles[to], _tiles[from]);
        return true;
    }

    /// One step earlier/later among the tiles belonging to `pageId`, keeping other pages untouched.
    public bool StepOnPage(string id, int delta, string pageId)
    {
        var onPage = TilesOn(pageId);
        var from = onPage.FindIndex(t => t.Id == id);
        var to = from + delta;
        if (from < 0 || to < 0 || to >= onPage.Count) return false;
        var ids = onPage.Select(t => t.Id).ToList();
        (ids[from], ids[to]) = (ids[to], ids[from]);
        ReorderOnPage(ids, pageId);
        return true;
    }

    /// The tiles in `order` (ids); any not named keep their place after them (none is ever dropped).
    public void Reorder(IEnumerable<string> order)
    {
        var byID = new Dictionary<string, QuickTile>();
        foreach (var t in _tiles) byID.TryAdd(t.Id, t);
        var next = new List<QuickTile>();
        foreach (var id in order)
            if (byID.Remove(id, out var t)) next.Add(t);
        next.AddRange(_tiles.Where(t => byID.ContainsKey(t.Id)));
        _tiles.Clear();
        _tiles.AddRange(next);
    }

    /// Reorders only the tiles on `pageId` according to `order`, keeping other pages' tiles untouched.
    public void ReorderOnPage(IEnumerable<string> order, string pageId)
    {
        var target = string.IsNullOrEmpty(pageId) ? FavoritePage.MainId : pageId;
        var byID = new Dictionary<string, QuickTile>();
        foreach (var t in _tiles.Where(t => t.ResolvedPageId == target)) byID.TryAdd(t.Id, t);
        var ordered = new List<QuickTile>();
        foreach (var id in order)
            if (byID.Remove(id, out var t)) ordered.Add(t);
        ordered.AddRange(_tiles.Where(t => t.ResolvedPageId == target && byID.ContainsKey(t.Id)));
        var idx = 0;
        for (var i = 0; i < _tiles.Count; i++)
        {
            if (_tiles[i].ResolvedPageId == target && idx < ordered.Count)
                _tiles[i] = ordered[idx++];
        }
    }

    /// [favorites-retired] Legacy Favorites pages (`hqn.favorites`) join once as page tiles.
    public bool AbsorbFavorites(IEnumerable<string> ids, IReadOnlyDictionary<string, (string Title, string Symbol)> pages)
    {
        var before = _tiles.ToList();
        _tiles.RemoveAll(t => t.Known == QuickTileKind.Page && t.Page == "favorites");
        var have = _tiles.Where(t => t.Known == QuickTileKind.Page && t.Page != null).Select(t => t.Page!).ToHashSet();
        foreach (var id in ids)
        {
            if (string.IsNullOrEmpty(id) || id is "favorites" or QuickTileStore.RowID || !have.Add(id)) continue;
            if (!pages.TryGetValue(id, out var page)) continue;
            _tiles.Add(QuickTile.Create(QuickTileKind.Page, id: "favorite-" + id, name: page.Title, symbol: page.Symbol) with
            {
                Page = id,
                PageName = page.Title,
            });
        }
        return !_tiles.SequenceEqual(before);
    }

    public bool Equals(QuickTileList? other) =>
        other != null && Seeded == other.Seeded && _tiles.SequenceEqual(other._tiles) && _pages.SequenceEqual(other._pages);

    public override bool Equals(object? obj) => Equals(obj as QuickTileList);

    public override int GetHashCode() => HashCode.Combine(Seeded, _tiles.Count, _pages.Count);
}

/// The list's place on this device (`QuickTileStore`): JSON text under `hqn.quickActions` in an `IKeyValueStore`.
public static class QuickTileStore
{
    public const string Key = "hqn.quickActions";
    /// A stored list this build could not read is copied here once, before anything is written over it.
    public const string UnreadableKey = "hqn.quickActions.unreadable";
    public const string CurrentPageKey = "hqn.quickActions.currentPage";
    public const string HideOtherGatewaysKey = "hqn.quickActions.hideOtherGateways";
    public const int Version = 1;
    /// The page's own More row id (and its tab's page id): never a tile of itself.
    public const string RowID = "quick-actions";

    /// Hook notified on local saves so `FavoritesSync` pushes to the gateway without coupling the pure store.
    public static Action? OnLocalSave { get; set; }

    /// Starter IDs, so first-contact sync can distinguish an unedited starter list from a customized one.
    public static readonly IReadOnlySet<string> StarterIds = new HashSet<string>(
        ["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"],
        StringComparer.Ordinal);

    /// The stored envelope `{version, seeded?, tiles, pages?}`; null when it can't be read as one. Entries that can't
    /// be read as tiles are kept as unreadable tiles.
    public static QuickTileList? Decode(string text) => Decode(text, out _);

    private static QuickTileList? Decode(string text, out long? version)
    {
        version = null;
        try
        {
            using var doc = JsonDocument.Parse(text, QuickTileJson.ReadOptions);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            var fields = QuickTileJson.Fields(doc.RootElement);
            version = ReadVersion(fields.GetValueOrDefault("version"));
            if (version == null) return null;
            var seeded = fields.GetValueOrDefault("seeded");
            var rows = fields.GetValueOrDefault("tiles");
            var pagesEl = fields.GetValueOrDefault("pages");
            if (rows.ValueKind != JsonValueKind.Array ||
                seeded.ValueKind is not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Undefined or JsonValueKind.Null) ||
                pagesEl.ValueKind is not (JsonValueKind.Array or JsonValueKind.Undefined or JsonValueKind.Null))
                return null;
            var tiles = rows.EnumerateArray().Select(e => QuickTile.Read(e) ?? QuickTile.FromUnreadable(QuickTileJson.Value(e))).ToList();
            List<FavoritePage>? pages = null;
            if (pagesEl.ValueKind == JsonValueKind.Array)
            {
                pages = [];
                foreach (var p in pagesEl.EnumerateArray())
                {
                    if (FavoritePage.Read(p) is not { } page) return null;
                    pages.Add(page);
                }
            }
            return new QuickTileList(tiles, seeded.ValueKind is JsonValueKind.True or JsonValueKind.False ? seeded.GetBoolean() : tiles.Count > 0, pages);
        }
        // GetString (including a property name) rejects an unpaired JSON surrogate with InvalidOperationException.
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return null; }
    }

    /// An integer `version` (Swift decodes it as Int); null when missing or not one.
    private static long? ReadVersion(JsonElement v)
    {
        if (v.ValueKind != JsonValueKind.Number) return null;
        if (v.TryGetInt64(out var integer)) return integer; // never round an integer version through Double
        var d = v.GetDouble();
        if (!double.IsInteger(d) || d < long.MinValue || d >= (double)long.MaxValue) return null;
        if (Math.Abs(d) < (1L << 53)) return (long)d;

        // Beyond Double's consecutive integers, Foundation rescales the decimal significand as UInt64.
        // Ignore trailing zeroes; do not round a fractional token up, or admit a significand too large to read.
        var digits = QuickTileJson.Mantissa(v).TrimStart('-').ToString().Replace(".", "").TrimEnd('0');
        if (!ulong.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out _) ||
            !v.TryGetDecimal(out var m) || m <= long.MinValue) return null;
        return (long)m;
    }

    public static string? Encode(QuickTileList list, long version = Version)
    {
        var tiles = new JsonArray();
        foreach (var t in list.Tiles) tiles.Add(t.ToJson());
        var envelope = new JsonObject { ["version"] = version, ["seeded"] = list.Seeded, ["tiles"] = tiles };
        if (list.Pages.Count > 0)
        {
            var pages = new JsonArray();
            foreach (var p in list.Pages) pages.Add(p.ToJson());
            envelope["pages"] = pages;
        }
        try { return QuickTileJson.Canonical(envelope); }
        catch (InvalidOperationException) { return null; } // exceeds the encoder's nesting limit: don't overwrite the list
    }

    public static QuickTileList Load(IKeyValueStore store)
    {
        if (store.Get(Key) is not { } text) return new QuickTileList();
        if (Decode(text) is { } list) return list;
        // Unreadable as a whole: kept aside (never wiped), and the starter set is not offered over it.
        if (store.Get(UnreadableKey) == null) store.Set(UnreadableKey, text);
        return new QuickTileList([], seeded: true);
    }

    /// Stores `list` (marking the stored copy seeded: the person has a list now). Returns whether it changed.
    public static bool Save(QuickTileList list, IKeyValueStore store, bool notifySync = true)
    {
        var next = list.Copy();
        next.Seeded = true;
        var current = store.Get(Key);
        long? version = null;
        var stored = current == null ? null : Decode(current, out version);
        if (next.Equals(stored)) return false;
        if (current != null && stored == null && store.Get(UnreadableKey) == null) store.Set(UnreadableKey, current);
        // A newer build's version number stays (its entries were kept as written).
        if (Encode(next, Math.Max(version ?? Version, Version)) is not { } text) return false;
        store.Set(Key, text);
        if (notifySync) OnLocalSave?.Invoke();
        return true;
    }

    public static string CurrentPage(IKeyValueStore store)
    {
        var stored = store.Get(CurrentPageKey);
        return string.IsNullOrEmpty(stored) ? FavoritePage.MainId : stored;
    }

    public static void SetCurrentPage(string id, IKeyValueStore store) =>
        store.Set(CurrentPageKey, string.IsNullOrEmpty(id) ? FavoritePage.MainId : id);

    public static bool HidesOtherGateways(IKeyValueStore store) =>
        string.Equals(store.Get(HideOtherGatewaysKey), "true", StringComparison.OrdinalIgnoreCase);

    public static void SetHidesOtherGateways(bool hide, IKeyValueStore store) =>
        store.Set(HideOtherGatewaysKey, hide ? "true" : null);

    /// The list to show: the stored one, or the starter set the first time there's a bot to make it for.
    public static (QuickTileList List, bool Seeded) ListToShow(QuickTileList stored, (string Profile, string Name)? firstBot)
    {
        if (stored.Tiles.Count > 0 || stored.Seeded || firstBot is not { } bot) return (stored, false);
        return (new QuickTileList(Starter(bot.Profile, bot.Name), seeded: true), true);
    }

    public static bool IsUneditedStarter(QuickTileList list) =>
        list.Pages.Count == 0 && list.Tiles.Count > 0 && list.Tiles.Select(t => t.Id).ToHashSet(StringComparer.Ordinal).SetEquals(StarterIds);

    /// Voice Memo, Talk, New Chat (wide), Add Task and Search Chats, for the roster's first bot.
    public static IReadOnlyList<QuickTile> Starter(string bot, string name)
    {
        QuickTile ForBot(QuickTile t) => t with { Bot = bot, BotName = name };
        return
        [
            ForBot(QuickTile.Create(QuickTileKind.Memo, id: "starter-memo")),
            ForBot(QuickTile.Create(QuickTileKind.Talk, id: "starter-talk")),
            ForBot(QuickTile.Create(QuickTileKind.NewChat, id: "starter-new-chat", wide: true)) with { Flag = true },
            QuickTile.Create(QuickTileKind.AddTask, id: "starter-add-task"),
            QuickTile.Create(QuickTileKind.Search, id: "starter-search"),
        ];
    }
}

/// Curated starter presets users can add or apply from Favorites (`FavoritePreset` in `QuickTiles.swift`).
public enum FavoritePreset { CommandCenter, DailyFocus, VoiceFirst, BuilderOps }

public static class FavoritePresets
{
    public static readonly FavoritePreset[] All =
    [
        FavoritePreset.CommandCenter, FavoritePreset.DailyFocus, FavoritePreset.VoiceFirst, FavoritePreset.BuilderOps,
    ];

    public static string Raw(this FavoritePreset preset) => preset switch
    {
        FavoritePreset.CommandCenter => "commandCenter",
        FavoritePreset.DailyFocus => "dailyFocus",
        FavoritePreset.VoiceFirst => "voiceFirst",
        FavoritePreset.BuilderOps => "builderOps",
        _ => "commandCenter",
    };

    public static string Title(this FavoritePreset preset) => preset switch
    {
        FavoritePreset.CommandCenter => "Command Center",
        FavoritePreset.DailyFocus => "Daily Focus",
        FavoritePreset.VoiceFirst => "Voice & Capture",
        FavoritePreset.BuilderOps => "Builder & Ops",
        _ => "Command Center",
    };

    public static string Subtitle(this FavoritePreset preset) => preset switch
    {
        FavoritePreset.CommandCenter => "Needs You, Today’s tasks, live bot, quick strip, and status.",
        FavoritePreset.DailyFocus => "Today’s tasks, active goal, quick capture, and voice.",
        FavoritePreset.VoiceFirst => "One-tap Memo, Talk, Quick Ask, and Add Task.",
        FavoritePreset.BuilderOps => "Gateway status, Usage, Kanban, Jobs, Terminal, and Changes.",
        _ => "",
    };

    public static string Symbol(this FavoritePreset preset) => preset switch
    {
        FavoritePreset.CommandCenter => "square.grid.2x2.fill",
        FavoritePreset.DailyFocus => "sun.max.fill",
        FavoritePreset.VoiceFirst => "waveform",
        FavoritePreset.BuilderOps => "terminal.fill",
        _ => "square.grid.2x2.fill",
    };

    public static IReadOnlyList<QuickTile> Tiles(
        this FavoritePreset preset,
        (string Profile, string Name)? bot,
        (string Id, string Title)? goal = null,
        string pageId = FavoritePage.MainId)
    {
        var pId = string.IsNullOrEmpty(pageId) || pageId == FavoritePage.MainId ? null : pageId;
        QuickTile Stamp(QuickTile tile) => tile with { PageId = pId };
        QuickTile ForBot(QuickTile tile) => bot is { } b ? Stamp(tile) with { Bot = b.Profile, BotName = b.Name } : Stamp(tile);

        switch (preset)
        {
            case FavoritePreset.CommandCenter:
            {
                var list = new List<QuickTile>();
                if (bot != null)
                {
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.Memo, name: "Memo", size: QuickTileSize.Mini)));
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.Talk, name: "Talk", size: QuickTileSize.Mini)));
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.QuickAsk, name: "Ask", size: QuickTileSize.Mini)) with { Flag = true });
                    list.Add(Stamp(QuickTile.Create(QuickTileKind.AddTask, name: "Task", symbol: "plus.circle.fill", size: QuickTileSize.Mini)));
                }
                list.Add(Stamp(QuickTile.Create(QuickTileKind.NeedsYou, name: "Needs You", size: QuickTileSize.Wide)));
                list.Add(Stamp(QuickTile.Create(QuickTileKind.Tasks, name: "Today", size: QuickTileSize.Wide)) with
                {
                    TaskView = "today",
                    TaskViewName = "Today",
                });
                if (bot is { } b)
                {
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.BotCard, name: b.Name, size: QuickTileSize.Wide)));
                }
                list.Add(Stamp(QuickTile.Create(QuickTileKind.GatewayStatus, name: "Gateway", size: QuickTileSize.Small)));
                list.Add(Stamp(QuickTile.Create(QuickTileKind.Usage, name: "Usage", size: QuickTileSize.Small)) with { Days = 7 });
                return list;
            }
            case FavoritePreset.DailyFocus:
            {
                var list = new List<QuickTile>
                {
                    Stamp(QuickTile.Create(QuickTileKind.Tasks, name: "Today", size: QuickTileSize.Large)) with
                    {
                        TaskView = "today",
                        TaskViewName = "Today",
                    },
                };
                if (goal is { } g)
                {
                    list.Add(Stamp(QuickTile.Create(QuickTileKind.Goal, name: g.Title, size: QuickTileSize.Wide)) with
                    {
                        GoalId = g.Id,
                        GoalName = g.Title,
                    });
                }
                list.Add(Stamp(QuickTile.Create(QuickTileKind.NeedsYou, name: "Needs You", size: QuickTileSize.Wide)));
                list.Add(Stamp(QuickTile.Create(QuickTileKind.AddTask, name: "Add Task", size: QuickTileSize.Small)));
                if (bot != null) list.Add(ForBot(QuickTile.Create(QuickTileKind.Memo, size: QuickTileSize.Small)));
                else list.Add(Stamp(QuickTile.Create(QuickTileKind.Search, size: QuickTileSize.Small)));
                return list;
            }
            case FavoritePreset.VoiceFirst:
            {
                var list = new List<QuickTile>();
                if (bot is { } b)
                {
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.Memo, name: "Voice Memo", size: QuickTileSize.Small)));
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.Talk, name: "Talk", size: QuickTileSize.Small)));
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.QuickAsk, name: "Quick Ask", size: QuickTileSize.Wide)) with { Flag = true });
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.NewChat, name: "New Chat", size: QuickTileSize.Wide)) with { Flag = true });
                    list.Add(ForBot(QuickTile.Create(QuickTileKind.BotCard, name: b.Name, size: QuickTileSize.Wide)));
                }
                list.Add(Stamp(QuickTile.Create(QuickTileKind.AddTask, size: QuickTileSize.Small)));
                list.Add(Stamp(QuickTile.Create(QuickTileKind.Search, size: QuickTileSize.Small)));
                return list;
            }
            case FavoritePreset.BuilderOps:
            default:
                return
                [
                    Stamp(QuickTile.Create(QuickTileKind.GatewayStatus, name: "Gateway Status", size: QuickTileSize.Wide)),
                    Stamp(QuickTile.Create(QuickTileKind.Usage, name: "7-Day Usage", size: QuickTileSize.Wide)) with { Days = 7 },
                    Stamp(QuickTile.Create(QuickTileKind.JobCard, name: "Upcoming Jobs", size: QuickTileSize.Wide)),
                    Stamp(QuickTile.Create(QuickTileKind.Kanban, name: "Kanban", size: QuickTileSize.Wide)),
                    Stamp(QuickTile.Create(QuickTileKind.Page, name: "Terminal", symbol: "apple.terminal.fill", color: QuickTileColor.Gray, size: QuickTileSize.Small)) with
                    {
                        Page = "terminal",
                        PageName = "Terminal",
                    },
                    Stamp(QuickTile.Create(QuickTileKind.Page, name: "Changes", symbol: "plus.forwardslash.minus", color: QuickTileColor.Green, size: QuickTileSize.Small)) with
                    {
                        Page = "review",
                        PageName = "Changes",
                    },
                ];
        }
    }
}

/// Pure deduplication and toggle rules behind `FavoritesPinAction` (`App/QuickActions/FavoritesPinAction.swift`).
public static class FavoritesPinRules
{
    public static bool Contains(IKeyValueStore store, Func<QuickTile, bool> match) =>
        QuickTileStore.Load(store).Tiles.Any(match);

    /// Toggles an item in Favorites, seeding the starter set first if the store was untouched, stamping the current
    /// custom page and gateway id on additions, and persisting via `QuickTileStore.Save`. Returns true if added.
    public static bool Toggle(
        IKeyValueStore store,
        Func<QuickTile, bool> match,
        Func<QuickTile> make,
        (string Profile, string Name)? firstBot = null,
        string? gatewayId = null)
    {
        var list = QuickTileStore.Load(store);
        if (list.Tiles.Count == 0 && !list.Seeded && firstBot != null)
            list = QuickTileStore.ListToShow(list, firstBot).List;
        var existing = list.Tiles.FirstOrDefault(match);
        bool added;
        if (existing != null)
        {
            list.Remove(existing.Id);
            added = false;
        }
        else
        {
            var tile = make();
            var current = QuickTileStore.CurrentPage(store);
            if (current != FavoritePage.MainId && list.AllPages.Any(p => p.Id == current))
                tile = tile with { PageId = current };
            if (!string.IsNullOrEmpty(gatewayId))
                tile = tile with { GatewayId = gatewayId };
            list.Add(tile);
            added = true;
        }
        QuickTileStore.Save(list, store);
        return added;
    }

    public static Func<QuickTile, bool> BotMatch(string profile) =>
        t => (t.Known is QuickTileKind.BotCard or QuickTileKind.OpenChat) && t.Bot == profile;

    public static Func<QuickTile, bool> RoomMatch(string roomKey) =>
        t => t.Known == QuickTileKind.GroupChat && t.RoomKey == roomKey;

    public static Func<QuickTile, bool> SessionMatch(string sessionId) =>
        t => t.Known == QuickTileKind.ChatSession && t.SessionId == sessionId;

    public static Func<QuickTile, bool> DashboardTileMatch(string pinId) =>
        t => t.Known == QuickTileKind.DashboardTile && t.Pin == pinId;

    public static Func<QuickTile, bool> GoalMatch(string goalId) =>
        t => t.Known == QuickTileKind.Goal && t.GoalId == goalId;

    public static Func<QuickTile, bool> JobMatch(string jobKey) =>
        t => (t.Known is QuickTileKind.JobCard or QuickTileKind.RunJob) && t.Job == jobKey;

    public static Func<QuickTile, bool> TaskViewMatch(string viewKey) =>
        t => t.Known == QuickTileKind.Tasks && (t.TaskView ?? "today") == viewKey;
}

/// JSON written as the Mac's JSONEncoder with .sortedKeys writes it: compact, keys in order, whole numbers as integers.
internal static class QuickTileJson
{
    // Foundation reads up to 512 nested containers, but encodes at most 511.
    internal static readonly JsonDocumentOptions ReadOptions = new() { MaxDepth = 512 };
    private static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, MaxDepth = 511 };

    // Swift String equality is ordinal after canonical normalization, not linguistic/case-insensitive comparison.
    // U+FFFE is valid in JSON but .NET refuses to normalize it. It cannot compose across either neighbor.
    private static string TextKey(string text) => text.Contains('\uFFFE')
        ? string.Join('\uFFFE', text.Split('\uFFFE').Select(s => s.Normalize())) : text.Normalize();

    internal static readonly IEqualityComparer<string> Text = EqualityComparer<string>.Create(
        (a, b) => a == b || a != null && b != null && TextKey(a) == TextKey(b),
        s => TextKey(s).GetHashCode(StringComparison.Ordinal));

    // Keep the first spelling and value. In particular, never decode the value of an equivalent later key:
    // it might not be representable, while the retained object and its siblings are perfectly readable.
    internal static Dictionary<string, JsonElement> Fields(JsonElement value)
    {
        var fields = new Dictionary<string, JsonElement>(Text);
        foreach (var p in value.EnumerateObject()) fields.TryAdd(p.Name, p.Value);
        return fields;
    }

    internal static JsonObject Object(Dictionary<string, JsonElement> fields) =>
        new(fields.Select(p => KeyValuePair.Create(p.Key, Value(p.Value))));

    internal static ReadOnlySpan<char> Mantissa(JsonElement number)
    {
        var text = number.GetRawText().AsSpan();
        var e = text.IndexOfAny('e', 'E');
        return e < 0 ? text : text[..e];
    }

    private static bool CanReadDouble(JsonElement number)
    {
        var d = number.GetDouble();
        // JSONDecoder rejects both overflow and nonzero magnitudes rounded to zero, but accepts literal zero.
        return double.IsFinite(d) && (d != 0 || !Mantissa(number).ContainsAnyInRange('1', '9'));
    }

    internal static JsonNode? Value(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Object => Object(Fields(value)),
        JsonValueKind.Array => new JsonArray(value.EnumerateArray().Select(Value).ToArray()),
        JsonValueKind.Number when !CanReadDouble(value) => throw new JsonException("Number not representable as a JSONValue"),
        _ => JsonValue.Create(value.Clone()),
    };

    internal static bool SameValue(string? a, string? b)
    {
        if (a == b) return true; // copies and ordinary reloads; no reparse on redraw
        if (a == null || b == null) return false;
        try
        {
            using var left = JsonDocument.Parse(a, ReadOptions);
            using var right = JsonDocument.Parse(b, ReadOptions);
            return SameValue(left.RootElement, right.RootElement);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException) { return false; }
    }

    private static bool SameValue(JsonElement a, JsonElement b)
    {
        if (a.ValueKind != b.ValueKind) return false;
        switch (a.ValueKind)
        {
            case JsonValueKind.Object:
                var right = Fields(b);
                foreach (var p in a.EnumerateObject())
                    if (!right.Remove(p.Name, out var v) || !SameValue(p.Value, v)) return false;
                return right.Count == 0;
            case JsonValueKind.Array:
                if (a.GetArrayLength() != b.GetArrayLength()) return false;
                var items = b.EnumerateArray();
                foreach (var item in a.EnumerateArray())
                {
                    items.MoveNext();
                    if (!SameValue(item, items.Current)) return false;
                }
                return true;
            case JsonValueKind.String: return Text.Equals(a.GetString(), b.GetString());
            case JsonValueKind.Number: return a.GetDouble() == b.GetDouble();
            default: return true; // null, true or false: the kind identifies the value
        }
    }

    public static string Canonical(JsonNode? node)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, Options)) Write(writer, node);
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static void Write(Utf8JsonWriter w, JsonNode? node)
    {
        switch (node)
        {
            case null: w.WriteNullValue(); break;
            case JsonObject o:
                w.WriteStartObject();
                foreach (var (key, value) in o.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    w.WritePropertyName(key);
                    Write(w, value);
                }
                w.WriteEndObject();
                break;
            case JsonArray a:
                w.WriteStartArray();
                foreach (var e in a) Write(w, e);
                w.WriteEndArray();
                break;
            case JsonValue v:
                switch (v.GetValueKind())
                {
                    case JsonValueKind.String: w.WriteStringValue(v.GetValue<string>()); break;
                    case JsonValueKind.True: w.WriteBooleanValue(true); break;
                    case JsonValueKind.False: w.WriteBooleanValue(false); break;
                    case JsonValueKind.Number:
                        // The envelope's version is a typed Int64; opaque JSONValue numbers are Doubles.
                        if (!v.TryGetValue(out JsonElement number)) { v.WriteTo(w); break; }
                        var d = number.GetDouble();
                        if (Math.Round(d) == d && Math.Abs(d) < 9.007e15) w.WriteNumberValue((long)d);
                        else if (double.IsFinite(d)) w.WriteNumberValue(d);
                        else w.WriteNullValue();
                        break;
                    default: w.WriteNullValue(); break;
                }
                break;
        }
    }
}
