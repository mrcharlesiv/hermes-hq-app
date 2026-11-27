using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Appearance › Chats › Thinking Bar (App/Settings/Appearance/AppearancePage.swift):
/// shows or hides the live thinking summary bar above/inside streaming replies. On by default.
public static class ThinkingBarRow
{
    public const string Key = "hqn.thinkingBar";
    public const string Label = "Thinking Bar";
    public const string RowTarget = "row:thinking-bar";
    public const string AutomationId = "theme.thinkingBar";
    public const string Note = "Shows a live summary while the bot is reasoning through a reply.";

    public static IPreferences? Store { get; set; }
    public static event Action? Changed;

    public static bool IsOn
    {
        get => Store?.Get(Key) != "false";
        set { Store?.Set(Key, value ? null : "false"); Changed?.Invoke(); }
    }
}

/// Appearance › Bots & Sessions › Chats Under Bots (5-choice selector matching Mac):
/// how many recent chats expand underneath each bot in the sidebar.
public enum ChatsUnderBotsChoice { Off, One, Three, Five, All }

public static class ChatsUnderBotsRow
{
    public const string Key = "hqn.sidebar.chatsUnderBots";
    public const string Label = "Chats Under Bots";
    public const string RowTarget = "row:chats-under-bots";
    public const string AutomationId = "theme.chatsUnderBots";
    public const string Note = "Shows each bot’s recent chats directly beneath it in the sidebar.";

    public static IPreferences? Store { get; set; }
    public static event Action? Changed;

    public static readonly (string Title, ChatsUnderBotsChoice Value)[] Options =
    [
        ("Off", ChatsUnderBotsChoice.Off),
        ("1", ChatsUnderBotsChoice.One),
        ("3", ChatsUnderBotsChoice.Three),
        ("5", ChatsUnderBotsChoice.Five),
        ("All", ChatsUnderBotsChoice.All),
    ];

    public static string Raw(this ChatsUnderBotsChoice c) => c switch
    {
        ChatsUnderBotsChoice.Off => "0",
        ChatsUnderBotsChoice.One => "1",
        ChatsUnderBotsChoice.Three => "3",
        ChatsUnderBotsChoice.Five => "5",
        _ => "all",
    };

    public static string Title(this ChatsUnderBotsChoice c) => c switch
    {
        ChatsUnderBotsChoice.Off => "Off",
        ChatsUnderBotsChoice.One => "1",
        ChatsUnderBotsChoice.Three => "3",
        ChatsUnderBotsChoice.Five => "5",
        _ => "All",
    };

    public static int? Limit(this ChatsUnderBotsChoice c) => c switch
    {
        ChatsUnderBotsChoice.Off => 0,
        ChatsUnderBotsChoice.One => 1,
        ChatsUnderBotsChoice.Three => 3,
        ChatsUnderBotsChoice.Five => 5,
        _ => null,
    };

    public static ChatsUnderBotsChoice Parse(string? raw) => raw switch
    {
        "0" or "off" => ChatsUnderBotsChoice.Off,
        "1" => ChatsUnderBotsChoice.One,
        "3" => ChatsUnderBotsChoice.Three,
        "5" => ChatsUnderBotsChoice.Five,
        "all" => ChatsUnderBotsChoice.All,
        _ => ChatsUnderBotsChoice.Three,
    };

    public static ChatsUnderBotsChoice Current
    {
        get => Parse(Store?.Get(Key));
        set
        {
            Store?.Set(Key, value == ChatsUnderBotsChoice.Three ? null : value.Raw());
            Changed?.Invoke();
        }
    }
}
