using Hermes.Core.Transcripts;

namespace Hermes.Core.Sessions;

/// How the connector down a bot's chats looks (App/Bots/BotChatsUnder.swift `BotChatsStyle`, `c8d7bdd88`):
/// curved elbows (default), swept arrows, spline fan, tapered quill, metro track, soft rail, plain line, dividers, or none.
public enum BotChatsStyleKind
{
    Branch,
    Arrows,
    Splines,
    Quill,
    Dots,
    Rail,
    Line,
    Dividers,
    None,
}

/// Device preference for the connector style drawn beside a bot's chats (`hq.bots.chatsUnder.style`).
public static class BotChatsStylePrefs
{
    public const string PrefKey = "hq.bots.chatsUnder.style";

    public static IPreferences? Store { get; set; }
    public static event Action? Changed;

    private static BotChatsStyleKind _memory = BotChatsStyleKind.Branch;

    public static IReadOnlyList<BotChatsStyleKind> All { get; } =
    [
        BotChatsStyleKind.Branch,
        BotChatsStyleKind.Arrows,
        BotChatsStyleKind.Splines,
        BotChatsStyleKind.Quill,
        BotChatsStyleKind.Dots,
        BotChatsStyleKind.Rail,
        BotChatsStyleKind.Line,
        BotChatsStyleKind.Dividers,
        BotChatsStyleKind.None,
    ];

    public static BotChatsStyleKind Current
    {
        get => Store != null ? Read(Store) : _memory;
        set
        {
            var prev = Current;
            _memory = value;
            if (Store != null) Write(Store, value);
            if (prev != value) Changed?.Invoke();
        }
    }

    public static BotChatsStyleKind Read(IPreferences? prefs) => Parse(prefs?.Get(PrefKey));

    public static bool Write(IPreferences? prefs, BotChatsStyleKind kind)
    {
        if (prefs == null) return false;
        var raw = Raw(kind);
        if (prefs.Get(PrefKey) == raw) return false;
        prefs.Set(PrefKey, raw);
        return true;
    }

    public static BotChatsStyleKind Parse(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "branch" => BotChatsStyleKind.Branch,
        "arrows" => BotChatsStyleKind.Arrows,
        "splines" => BotChatsStyleKind.Splines,
        "quill" => BotChatsStyleKind.Quill,
        "dots" => BotChatsStyleKind.Dots,
        "rail" => BotChatsStyleKind.Rail,
        "line" => BotChatsStyleKind.Line,
        "dividers" => BotChatsStyleKind.Dividers,
        "none" => BotChatsStyleKind.None,
        _ => BotChatsStyleKind.Branch,
    };

    public static string Raw(BotChatsStyleKind kind) => kind.ToString().ToLowerInvariant();

    public static string Label(BotChatsStyleKind kind) => kind switch
    {
        BotChatsStyleKind.Branch => "Curved Elbows",
        BotChatsStyleKind.Arrows => "Swept Arrows",
        BotChatsStyleKind.Splines => "Spline Fan",
        BotChatsStyleKind.Quill => "Tapered Quill",
        BotChatsStyleKind.Dots => "Metro Track",
        BotChatsStyleKind.Rail => "Soft Rail",
        BotChatsStyleKind.Line => "Line",
        BotChatsStyleKind.Dividers => "Dividers",
        BotChatsStyleKind.None => "No Line",
        _ => "Curved Elbows",
    };

    /// The line ends at the last row's mark instead of short of its foot (App/Bots/BotChatsUnder.swift `marksRows`).
    public static bool MarksRows(BotChatsStyleKind kind) => kind is
        BotChatsStyleKind.Branch or BotChatsStyleKind.Arrows or BotChatsStyleKind.Splines
        or BotChatsStyleKind.Quill or BotChatsStyleKind.Dots or BotChatsStyleKind.Rail;
}
